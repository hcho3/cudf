/*
 * Copyright (c) 2020, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column_factories.hpp>
#include <cudf/column/column_view.hpp>
#include <cudf/detail/concatenate.cuh>
#include <cudf/detail/copy.hpp>
#include <cudf/detail/interop.hpp>
#include <cudf/detail/nvtx/ranges.hpp>
#include <cudf/detail/unary.hpp>
#include <cudf/dictionary/dictionary_factories.hpp>
#include <cudf/interop.hpp>
#include <cudf/null_mask.hpp>
#include <cudf/table/table_view.hpp>
#include <cudf/types.hpp>
#include <cudf/utilities/traits.hpp>
#include <cudf/utilities/type_dispatcher.hpp>

namespace cudf {

namespace detail {
data_type arrow_to_cudf_type(arrow::Type::type arrow_type)
{
  switch (arrow_type) {
    case arrow::Type::type::BOOL: return data_type(type_id::BOOL8);
    case arrow::Type::type::INT8: return data_type(type_id::INT8);
    case arrow::Type::type::INT16: return data_type(type_id::INT16);
    case arrow::Type::type::INT32: return data_type(type_id::INT32);
    case arrow::Type::type::INT64: return data_type(type_id::INT64);
    case arrow::Type::type::UINT8: return data_type(type_id::UINT8);
    case arrow::Type::type::UINT16: return data_type(type_id::UINT16);
    case arrow::Type::type::UINT32: return data_type(type_id::UINT32);
    case arrow::Type::type::UINT64: return data_type(type_id::UINT64);
    case arrow::Type::type::FLOAT: return data_type(type_id::FLOAT32);
    case arrow::Type::type::DOUBLE: return data_type(type_id::FLOAT64);
    case arrow::Type::type::DATE32: return data_type(type_id::TIMESTAMP_DAYS);
    case arrow::Type::type::DATE64: return data_type(type_id::TIMESTAMP_MILLISECONDS);
    case arrow::Type::type::STRING: return data_type(type_id::STRING);
    case arrow::Type::type::DICTIONARY: return data_type(type_id::DICTIONARY32);
    case arrow::Type::type::LIST: return data_type(type_id::LIST);
    default: CUDF_FAIL("Unsupported type_id conversion to cudf");
  }
}

namespace {
struct dispatch_to_cudf_column {
  template <typename T>
  std::enable_if_t<is_fixed_width<T>(), std::pair<std::unique_ptr<column>, column_view>> operator()(
    arrow::Array const& array,
    data_type type,
    bool skip_mask,
    rmm::mr::device_memory_resource* mr,
    cudaStream_t stream)
  {
    auto data_buffer = array.data()->buffers[1];
    auto num_rows    = data_buffer->size() / sizeof(T);
    auto has_nulls   = skip_mask ? false : array.null_bitmap_data() != nullptr;
    auto col         = make_fixed_width_column(
      type, num_rows, has_nulls ? mask_state::UNINITIALIZED : mask_state::UNALLOCATED, stream, mr);
    auto mutable_column_view = col->mutable_view();
    CUDA_TRY(cudaMemcpyAsync(mutable_column_view.data<void*>(),
                             data_buffer->data(),
                             data_buffer->size(),
                             cudaMemcpyHostToDevice,
                             stream));
    if (has_nulls) {
      CUDA_TRY(cudaMemcpyAsync(mutable_column_view.null_mask(),
                               array.null_bitmap_data(),
                               array.null_bitmap()->size(),
                               cudaMemcpyHostToDevice,
                               stream));
    }

    return std::make_pair<std::unique_ptr<column>, column_view>(
      std::move(col),
      cudf::detail::slice(col->view(),
                          static_cast<size_type>(array.offset()),
                          static_cast<size_type>(array.offset() + array.length())));
  }

  std::unique_ptr<rmm::device_buffer> get_mask_buffer(arrow::Array const& array,
                                                      rmm::mr::device_memory_resource* mr,
                                                      cudaStream_t stream)
  {
    std::unique_ptr<rmm::device_buffer> mask = std::make_unique<rmm::device_buffer>(0);
    if (array.null_bitmap_data() != nullptr) {
      mask = std::make_unique<rmm::device_buffer>(array.null_bitmap()->size(), stream, mr);
      CUDA_TRY(cudaMemcpyAsync(mask->data(),
                               array.null_bitmap_data(),
                               array.null_bitmap()->size(),
                               cudaMemcpyHostToDevice,
                               stream));
    }

    return std::move(mask);
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::string_view>::value,
                   std::pair<std::unique_ptr<column>, column_view>>
  operator()(arrow::Array const& array,
             data_type type,
             bool skip_mask,
             rmm::mr::device_memory_resource* mr,
             cudaStream_t stream)
  {
    auto str_array = static_cast<arrow::StringArray const*>(&array);
    auto offset_array                   = std::make_unique<arrow::Int32Array>(
      str_array->value_offsets()->size() / sizeof(int32_t), str_array->value_offsets(), nullptr);
    auto char_array = std::make_unique<arrow::Int8Array>(
      str_array->value_data()->size(), str_array->value_data(), nullptr);

    auto offsets_column =
      std::move(dispatch_to_cudf_column{}
                  .
                  operator()<int32_t>(*offset_array, data_type(type_id::INT32), true, mr, stream)
                  .first);
    auto chars_column =
      std::move(dispatch_to_cudf_column{}
                  .
                  operator()<int8_t>(*char_array, data_type(type_id::INT8), true, mr, stream)
                  .first);

    auto num_rows = offsets_column->size() - 1;
    auto out_col  = make_strings_column(num_rows,
                                       std::move(offsets_column),
                                       std::move(chars_column),
                                       UNKNOWN_NULL_COUNT,
                                       std::move(*get_mask_buffer(array, mr, stream)),
                                       stream,
                                       mr);

    return std::make_pair<std::unique_ptr<column>, column_view>(
      std::move(out_col),
      slice(out_col->view(),
            static_cast<size_type>(array.offset()),
            static_cast<size_type>(array.offset() + array.length())));
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::dictionary32>::value,
                   std::pair<std::unique_ptr<column>, column_view>>
  operator()(arrow::Array const& array,
             data_type type,
             bool skip_mask,
             rmm::mr::device_memory_resource* mr,
             cudaStream_t stream)
  {
    auto dict_array =
      static_cast<arrow::DictionaryArray const*>(&array);
    auto ind_type = arrow_to_cudf_type(dict_array->indices()->type()->id());
    auto indices  = type_dispatcher(
      ind_type, dispatch_to_cudf_column{}, *(dict_array->indices()), ind_type, true, mr, stream);
    std::unique_ptr<column> indices_column = nullptr;
    // If index type is not of type int32_t, then cast it to int32_t
    if (indices.first->type().id() != type_id::INT32) {
      if (indices.first->size() == dict_array->indices()->length()) {
        indices_column =
          cudf::detail::cast(indices.first->view(), data_type(type_id::INT32), mr, stream);
      } else {
        indices_column = cudf::detail::cast(indices.second, data_type(type_id::INT32), mr, stream);
      }
    } else {
      indices_column = (indices.first->size() == dict_array->indices()->length())
                         ? std::move(indices.first)
                         : std::make_unique<column>(indices.second, stream, mr);
    }

    auto dict_type   = arrow_to_cudf_type(dict_array->dictionary()->type()->id());
    auto keys        = type_dispatcher(dict_type,
                                dispatch_to_cudf_column{},
                                *(dict_array->dictionary()),
                                dict_type,
                                true,
                                mr,
                                stream);
    auto keys_column = (keys.first->size() == dict_array->dictionary()->length())
                         ? std::move(keys.first)
                         : std::make_unique<column>(keys.second, stream, mr);

    auto out_col = make_dictionary_column(std::move(keys_column),
                                          std::move(indices_column),
                                          std::move(*get_mask_buffer(array, mr, stream)),
                                          UNKNOWN_NULL_COUNT);

    return std::make_pair<std::unique_ptr<column>, column_view>(
      std::move(out_col),
      slice(out_col->view(),
            static_cast<size_type>(array.offset()),
            static_cast<size_type>(array.offset() + array.length())));
  }

  template <typename T>
  std::enable_if_t<std::is_same<T, cudf::list_view>::value,
                   std::pair<std::unique_ptr<column>, column_view>>
  operator()(arrow::Array const& array,
             data_type type,
             bool skip_mask,
             rmm::mr::device_memory_resource* mr,
             cudaStream_t stream)
  {
    auto list_array = static_cast<arrow::ListArray const*>(&array);
    auto offset_array                  = std::make_unique<arrow::Int32Array>(
      list_array->value_offsets()->size() / sizeof(int32_t), list_array->value_offsets(), nullptr);
    auto offsets = dispatch_to_cudf_column{}.operator()<int32_t>(
      *offset_array, data_type(type_id::INT32), true, mr, stream);
    auto offsets_column = (offsets.first->size() == offset_array->length())
                            ? std::move(offsets.first)
                            : std::make_unique<column>(offsets.second, stream, mr);

    auto child_type   = arrow_to_cudf_type(list_array->values()->type()->id());
    auto child        = type_dispatcher(child_type,
                                 dispatch_to_cudf_column{},
                                 *(list_array->values()),
                                 child_type,
                                 false,
                                 mr,
                                 stream);
    auto child_column = (child.first->size() == list_array->values()->length())
                          ? std::move(child.first)
                          : std::make_unique<column>(child.second, stream, mr);

    auto num_rows = offsets_column->size() - 1;
    auto out_col  = make_lists_column(num_rows,
                                     std::move(offsets_column),
                                     std::move(child_column),
                                     UNKNOWN_NULL_COUNT,
                                     std::move(*get_mask_buffer(array, mr, stream)));

    return std::make_pair<std::unique_ptr<column>, column_view>(
      std::move(out_col),
      slice(out_col->view(),
            static_cast<size_type>(array.offset()),
            static_cast<size_type>(array.offset() + array.length())));
  }

  template <typename T>
  std::enable_if_t<((!is_fixed_width<T>()) and (!is_compound<T>())),
                   std::pair<std::unique_ptr<column>, column_view>>
  operator()(arrow::Array const& array,
             data_type type,
             bool skip_mask,
             rmm::mr::device_memory_resource* mr,
             cudaStream_t stream)
  {
    CUDF_FAIL("Only fixed width and compund types are supported");
  }
};

}  // namespace

std::unique_ptr<table> arrow_to_cudf(arrow::Table const& input_table,
                                     rmm::mr::device_memory_resource* mr,
                                     cudaStream_t stream)
{
  std::vector<std::unique_ptr<column>> columns;
  auto chunked_arrays = input_table.columns();
  std::transform(
    chunked_arrays.begin(),
    chunked_arrays.end(),
    std::back_inserter(columns),
    [&mr, &stream](auto const& chunked_array) {
      std::vector<std::unique_ptr<column>> concat_columns;
      std::vector<column_view> concat_column_views;
      auto cudf_type    = arrow_to_cudf_type(chunked_array->type()->id());
      auto array_chunks = chunked_array->chunks();

      transform(
        array_chunks.begin(),
        array_chunks.end(),
        std::back_inserter(concat_columns),
        [&cudf_type, &concat_column_views, &mr, &stream](auto const& array_chunk) {
          auto col_and_view = type_dispatcher(
            cudf_type, dispatch_to_cudf_column{}, *array_chunk, cudf_type, false, mr, stream);
          concat_column_views.emplace_back(col_and_view.second);
          return std::move(col_and_view.first);
        });

      if ((concat_columns.size() == 1) and (concat_column_views[0].offset() == 0) and
          (concat_column_views[0].size() == concat_columns[0]->size())) {
        return std::move(concat_columns[0]);
      }
      {
        return cudf::detail::concatenate(concat_column_views, mr, stream);
      }
    });

  return std::make_unique<table>(std::move(columns));
}

}  // namespace detail

std::unique_ptr<table> arrow_to_cudf(arrow::Table const& input_table,
                                     rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();

  return detail::arrow_to_cudf(input_table, mr);
}

}  // namespace cudf
